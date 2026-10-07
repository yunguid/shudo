import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import { createActivityFromText } from "./activity_analysis.ts";
import {
  type Anthropic,
  baseParams,
  type BetaContentBlockParam,
  type BetaMessageParam,
  callClaudeStructured,
  CLAUDE_BILLING_MESSAGE,
  CLAUDE_MODELS,
  claudeClient,
  type ClaudeEffort,
  type ClaudeUsage,
  imageFromUrl,
  isClaudeBillingError,
  usageOf,
  webSearchTool,
} from "./claude.ts";
import { mergeBioDictation } from "./coach_bio.ts";
import { handleCardAction, parseCardAction } from "./coach_cards.ts";
import {
  allowedFiguresFor,
  buildCoachBrief,
  buildStatePack,
  type CoachContext,
  coachSystemBlocks,
  type CoachThreadRow,
  loadCoachContext,
  renderMemoryBlock,
} from "./coach_context.ts";
import {
  type CoachCopyPolicy,
  coachCopyReview,
  sanitizeCoachText,
  splitBubbles,
  stripPreamble,
} from "./coach_copy.ts";
import { type CoachJobRequest, dispatchCoachJob } from "./coach_dispatch.ts";
import {
  CHAT_FAILURE_FALLBACK,
  CHAT_REFUSAL_FALLBACK,
  WELLBEING_CARD_BODY,
  WELLBEING_RESOURCES,
} from "./coach_fallbacks.ts";
import {
  COACH_CHAT_RULES,
  COACH_PERSONA_VERSION,
  type CoachContextHint,
  contextHintRouting,
} from "./coach_persona.ts";
import {
  addDays,
  formatClock,
  isValidTimezone,
  localClock,
  weekdayOf,
} from "./coach_policy.ts";
import {
  claimCoachRun,
  COACH_MESSAGE_COLUMNS,
  type CoachMessageInput,
  type CoachMessageRow,
  completeCoachRun,
  failCoachRun,
  fetchCoachMessages,
  getCoachRuns,
  isClaimed,
  postUserCoachMessage,
  upsertStreamingCoachMessage,
} from "./coach_rpc.ts";
import {
  COACH_TOOL_DEFINITIONS,
  COACH_TOOL_STATUS_LABELS,
  COACH_TOOL_TIMEOUTS_MS,
  type CoachToolEnvironment,
  type CoachToolServices,
  DEFAULT_TOOL_TIMEOUT_MS,
  deterministicUuid,
  executeCoachTool,
} from "./coach_tools.ts";
import { addUsage, emptyUsage, recordCoachUsage } from "./coach_usage.ts";
import { createTextEntry } from "./entry_capture.ts";
import { HttpError } from "./errors.ts";
import { CORS_HEADERS, isUuid, withTimeout } from "./http.ts";
import {
  type LocationContext,
  researchNearbyFood,
  sanitizeLocationContext,
} from "./nearby_food.ts";
import { modelQuotaHttpError } from "./quotas.ts";

/// coach_chat: a texting conversation with the coach. The user message is
/// stored first, the turn runs detached (the database is the source of
/// truth), and the reply streams back as single-line SSE events.

export const COACH_CHAT_MODEL = CLAUDE_MODELS.sonnet;
export const TURN_BUDGET_MS = 110_000;
const TURN_RESERVE_MS = 8_000;
const MAX_MODEL_REQUESTS = 8;
const MAX_TOOL_CALLS = 12;
const MAX_PAUSE_CONTINUATIONS = 2;
const STREAM_WRITE_INTERVAL_MS = 650;
const KEEPALIVE_INTERVAL_MS = 10_000;
const MAX_TEXT_CHARACTERS = 4_000;
const HISTORY_LIMIT = 60;

// ---------------------------------------------------------------- SSE

export type CoachStreamEvent =
  | {
    type: "accepted";
    run_id: string;
    user_message: CoachMessageRow | null;
    duplicate: boolean;
  }
  | { type: "status"; label: string }
  | { type: "delta"; message_id: string; text: string }
  | { type: "message"; message: CoachMessageRow }
  | { type: "done"; run_id: string; message_ids: string[] }
  | { type: "error"; code: string; message: string; retryable: boolean };

/// One event per line: `data: {json}` + blank line. JSON escapes newlines,
/// so a client reading lines never has to rely on the blank delimiter.
export function encodeSseEvent(event: CoachStreamEvent): string {
  return `data: ${JSON.stringify(event)}\n\n`;
}

export const SSE_KEEPALIVE = ": keepalive\n\n";

export const SSE_HEADERS = {
  ...CORS_HEADERS,
  "content-type": "text/event-stream; charset=utf-8",
  "cache-control": "no-cache, no-transform",
  "x-accel-buffering": "no",
};

/// A write-only SSE response. Writes after the client disconnects are
/// swallowed: the turn keeps running and persisting regardless.
export class SseChannel {
  readonly response: Response;
  #writer: WritableStreamDefaultWriter<Uint8Array>;
  #encoder = new TextEncoder();
  #closed = false;
  #keepalive: number | null;

  constructor(keepaliveMs = KEEPALIVE_INTERVAL_MS) {
    const stream = new TransformStream<Uint8Array, Uint8Array>();
    this.#writer = stream.writable.getWriter();
    this.response = new Response(stream.readable, {
      status: 200,
      headers: SSE_HEADERS,
    });
    this.#keepalive = keepaliveMs > 0
      ? setInterval(() => this.#write(SSE_KEEPALIVE), keepaliveMs)
      : null;
  }

  get closed(): boolean {
    return this.#closed;
  }

  #write(chunk: string): void {
    if (this.#closed) return;
    this.#writer.write(this.#encoder.encode(chunk)).catch(() => {
      this.#shutdown();
    });
  }

  #shutdown(): void {
    this.#closed = true;
    if (this.#keepalive !== null) clearInterval(this.#keepalive);
    this.#keepalive = null;
  }

  send(event: CoachStreamEvent): void {
    this.#write(encodeSseEvent(event));
  }

  close(): void {
    if (this.#closed) return;
    this.#shutdown();
    this.#writer.close().catch(() => undefined);
  }
}

// ------------------------------------------------------------ requests

export type CoachInputMode = "typed" | "dictated" | "notification_reply";

export type CoachSendRequest = {
  clientRequestId: string;
  text: string;
  inputMode: CoachInputMode;
  speechEngine: string | null;
  localDay: string;
  timezone: string;
  attachmentPath: string | null;
  location: LocationContext | null;
  /// Where the global mic was: Today (null), Train, Body, or Bio.
  contextHint: CoachContextHint | null;
};

const CONTEXT_HINTS: readonly CoachContextHint[] = ["train", "body", "bio"];

/** The screen hint from the app; anything unknown is the general mic. */
export function parseContextHint(value: unknown): CoachContextHint | null {
  if (typeof value !== "string") return null;
  const hint = value.trim().toLowerCase();
  return CONTEXT_HINTS.find((item) => item === hint) ?? null;
}

export type CoachChatBody =
  | { kind: "send"; request: CoachSendRequest }
  | {
    kind: "action";
    clientRequestId: string;
    action: ReturnType<typeof parseCardAction>;
  };

function shortText(value: unknown, max: number): string | null {
  return typeof value === "string" && value.trim()
    ? value.trim().slice(0, max)
    : null;
}

/// LocationContext arrives from the phone; lane B3's sanitizer rebuilds it
/// field by field so no coordinate (or anything unexpected) rides along.
export function parseLocationContext(value: unknown): LocationContext | null {
  if (!value || typeof value !== "object") return null;
  return sanitizeLocationContext(value);
}

const SPEECH_ENGINES = new Set([
  "apple.speech_transcriber",
  "apple.dictation_transcriber",
  "apple.sf_speech_on_device",
]);

export function parseCoachChatBody(value: unknown): CoachChatBody {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpError(400, "Expected a JSON object");
  }
  const object = value as Record<string, unknown>;
  const clientRequestId = typeof object.client_request_id === "string"
    ? object.client_request_id.trim().toLowerCase()
    : "";
  if (!isUuid(clientRequestId)) {
    throw new HttpError(400, "client_request_id must be a UUID");
  }
  if (object.action !== undefined) {
    return {
      kind: "action",
      clientRequestId,
      action: parseCardAction(object.action),
    };
  }
  const text = typeof object.text === "string" ? object.text.trim() : "";
  if (text.length > MAX_TEXT_CHARACTERS) {
    throw new HttpError(413, "That message is too long");
  }
  const attachmentPath = shortText(object.attachment_path, 200);
  if (!text && !attachmentPath) {
    throw new HttpError(400, "Say something to the coach");
  }
  const localDay = typeof object.local_day === "string"
    ? object.local_day.trim()
    : "";
  if (
    !/^\d{4}-\d{2}-\d{2}$/u.test(localDay) ||
    new Date(`${localDay}T00:00:00Z`).toISOString().slice(0, 10) !== localDay
  ) throw new HttpError(400, "local_day must use YYYY-MM-DD");
  const timezone = typeof object.timezone === "string"
    ? object.timezone.trim()
    : "";
  if (!isValidTimezone(timezone)) {
    throw new HttpError(400, "timezone is not a valid IANA timezone");
  }
  const inputMode = object.input_mode === "dictated" ||
      object.input_mode === "notification_reply"
    ? object.input_mode
    : "typed";
  const engine = typeof object.speech_engine === "string"
    ? object.speech_engine.trim().toLowerCase()
    : "";
  return {
    kind: "send",
    request: {
      clientRequestId,
      text,
      inputMode,
      speechEngine: SPEECH_ENGINES.has(engine) ? engine : null,
      localDay,
      timezone,
      attachmentPath,
      location: parseLocationContext(object.location),
      contextHint: parseContextHint(object.context_hint),
    },
  };
}

export function validateAttachmentPath(
  userId: string,
  path: string | null,
): void {
  if (path === null) return;
  const pattern = new RegExp(
    `^${userId}/\\d{4}-\\d{2}-\\d{2}/chat-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.jpg$`,
    "u",
  );
  if (!pattern.test(path) || path.length > 160) {
    throw new HttpError(
      400,
      "attachment_path is not a coach photo you uploaded",
    );
  }
}

// ------------------------------------------------------------- safety

const WELLBEING_PATTERNS = [
  /\bpurg(?:e|ed|ing)\b/iu,
  /\blaxatives?\b/iu,
  /\bmake (?:myself|me) (?:throw up|puke|sick|vomit)\b/iu,
  /\bthrow(?:ing)? up (?:after|my food|what i ate|on purpose)\b/iu,
  /\bstarv(?:e|ing) myself\b/iu,
  /\b(?:not|didn['’]?t|haven['’]?t|stop(?:ped)?) eat(?:ing|en)? (?:on purpose|for (?:\d+|two|three|a few|several) days)\b/iu,
  /\b(?:guilty|ashamed|disgusted) (?:about|after|for) (?:eating|food|what i ate)\b/iu,
  /\b(?:scared|afraid|terrified) (?:of|to) (?:eat|eating|food|gain(?:ing)?)\b/iu,
  /\bpunish(?:ing)? myself\b/iu,
  /\b(?:in a )?dark place\b/iu,
  /\b(?:want|wanna) to (?:die|disappear|end it)\b/iu,
  /\bkill(?:ing)? myself\b/iu,
  /\bsuicid\w*/iu,
  /\bself[- ]harm\w*/iu,
  /\bhate myself\b/iu,
  /\bno point (?:anymore|in (?:anything|living|trying))\b/iu,
];

/** Deterministic wellbeing signal in Luke's own words (persona §6). */
export function detectWellbeingSignal(text: string): boolean {
  return WELLBEING_PATTERNS.some((pattern) => pattern.test(text));
}

// ------------------------------------------------------------ history

const THREAD_STUB =
  "(thread resumes; earlier days are summarized in your memory)";

/// Prior turns as plain text: no thinking, no tool blocks, so the history
/// only ever grows by appending. The window starts at yesterday so the
/// cached prefix moves once a day, not every turn.
export function renderHistory(
  thread: CoachThreadRow[],
  options: { localDay: string; excludeIds: Set<string> },
): Array<{ role: "user" | "assistant"; text: string }> {
  const start = addDays(options.localDay, -1);
  const turns: Array<{ role: "user" | "assistant"; text: string }> = [];
  for (const row of thread) {
    if (options.excludeIds.has(row.id) || row.local_day < start) continue;
    if (row.role === "system_event") continue;
    if (row.payload?.streaming === true) continue;
    const body = row.body.trim();
    const text = row.role === "user"
      ? row.kind === "photo" ? `(sent a photo) ${body}`.trim() : body
      : body;
    if (!text) continue;
    const role = row.role === "user" ? "user" : "assistant";
    const last = turns.at(-1);
    if (last && last.role === role) last.text = `${last.text}\n\n${text}`;
    else turns.push({ role, text });
  }
  if (turns[0]?.role === "assistant") {
    turns.unshift({ role: "user", text: THREAD_STUB });
  }
  return turns;
}

// --------------------------------------------------------- the turn

export type CoachTurnInput = {
  admin: SupabaseClient;
  userId: string;
  runId: string;
  claimToken: string;
  request: CoachSendRequest;
  userMessageId: string | null;
  now: Date;
};

export type CoachTurnDependencies = {
  client?: Anthropic;
  services?: Partial<CoachToolServices>;
  dispatchEntry?: (entryId: string) => void;
  loadContext?: typeof loadCoachContext;
  signedPhotoUrl?: (path: string) => Promise<string | null>;
  schedulePlan?: (job: CoachJobRequest) => void;
  clock?: () => number;
  budgetMs?: number;
};

export type CoachTurnOutcome = {
  status: "complete" | "failed" | "stale";
  replyMessageId: string;
  messageIds: string[];
  text: string;
  toolCalls: string[];
  usage: ClaudeUsage;
};

class LostRunFenceError extends Error {}

/// Streams reply text into the coach message row, at most every 650 ms.
class StreamingReply {
  body = "";
  #persisted = "";
  #lastWrite = 0;
  #chain: Promise<void> = Promise.resolve();
  #lost = false;

  constructor(
    readonly admin: SupabaseClient,
    readonly runId: string,
    readonly claimToken: string,
    readonly messageId: string,
    readonly emit: (event: CoachStreamEvent) => void,
    readonly clock: () => number,
    /// Payload carried on in-flight writes too (what the reply acknowledges),
    /// so a fast meal analysis already sees the chat acknowledged it.
    readonly extras: () => Record<string, unknown> = () => ({}),
  ) {}

  append(piece: string): void {
    if (!piece) return;
    this.body += piece;
    this.emit({ type: "delta", message_id: this.messageId, text: piece });
    if (this.clock() - this.#lastWrite >= STREAM_WRITE_INTERVAL_MS) {
      this.#schedule();
    }
  }

  #schedule(): void {
    this.#lastWrite = this.clock();
    const snapshot = this.body;
    this.#chain = this.#chain.then(async () => {
      if (this.#lost || snapshot === this.#persisted) return;
      const ok = await upsertStreamingCoachMessage(this.admin, {
        runId: this.runId,
        claimToken: this.claimToken,
        messageId: this.messageId,
        body: snapshot.slice(0, MAX_TEXT_CHARACTERS),
        payload: { persona_version: COACH_PERSONA_VERSION, ...this.extras() },
        done: false,
      }).catch((error) => {
        console.warn("coach_stream_write_failed", { message: String(error) });
        return true;
      });
      if (!ok) this.#lost = true;
      else this.#persisted = snapshot;
    });
  }

  async finish(body: string, payload: Record<string, unknown>): Promise<void> {
    await this.#chain;
    if (this.#lost) throw new LostRunFenceError("Coach reply fence was lost");
    const ok = await upsertStreamingCoachMessage(this.admin, {
      runId: this.runId,
      claimToken: this.claimToken,
      messageId: this.messageId,
      body: body.slice(0, MAX_TEXT_CHARACTERS),
      payload,
      model: typeof payload.model === "string" ? payload.model : null,
      done: true,
    });
    if (!ok) throw new LostRunFenceError("Coach reply fence was lost");
  }
}

const CHAT_REWRITE_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    bubbles: {
      type: "array",
      minItems: 1,
      maxItems: 3,
      items: { type: "string", maxLength: 450 },
    },
  },
  required: ["bubbles"],
} as const;

function wantsLongForm(text: string): boolean {
  return /\b(?:why|explain|how come|walk me through)\b/iu.test(text);
}

/// Bio merges reason over his whole bio; everything else is a quick text.
function chatEffort(request: CoachSendRequest): ClaudeEffort {
  const words = request.text.split(/\s+/u).filter(Boolean).length;
  return request.contextHint === "bio" || words > 120 ? "medium" : "low";
}

const HINT_LABEL: Record<CoachContextHint, string> = {
  train: " · from the Train screen",
  body: " · from the Body screen",
  bio: " · from the Bio screen",
};

function userTurnText(
  request: CoachSendRequest,
  context: CoachContext,
): string {
  const clock = localClock(context.now, request.timezone);
  // The weekday of the day he is on (after midnight the coach's 04:00 day
  // is still yesterday, but his calendar says today).
  const meta = `(${weekdayOf(request.localDay)} ${request.localDay} ${
    formatClock(clock.minutes)
  } · ${
    request.inputMode === "typed"
      ? "typed"
      : request.inputMode === "dictated"
      ? "dictated, may contain transcription slips"
      : "replied from a notification"
  }${request.contextHint ? HINT_LABEL[request.contextHint] : ""})`;
  return `${meta}\n${request.text || "(photo only)"}`;
}

/// The mid-conversation system note: who he is right now, the live state,
/// and where he spoke from. Server-written; his words never go in here.
export function liveStateNote(
  context: CoachContext,
  statePack: Record<string, unknown>,
  hint: CoachContextHint | null,
): string {
  const brief = buildCoachBrief(context, {
    includeHisWords: false,
    offerOpenQuestion: true,
  });
  const routing = contextHintRouting(hint);
  return `<brief>\n${brief}\n</brief>\n<live_state>${
    JSON.stringify(statePack)
  }</live_state>${routing ? `\n<routing>${routing}</routing>` : ""}`;
}

function ackedPayload(
  acked: { entryIds: string[]; activityIds: string[] },
): Record<string, unknown> {
  return {
    ...(acked.entryIds.length ? { acked_entry_ids: [...acked.entryIds] } : {}),
    ...(acked.activityIds.length
      ? { acked_activity_ids: [...acked.activityIds] }
      : {}),
  };
}

const REWRITE_HINTS: Partial<Record<string, string>> = {
  machinery:
    "it talked about the app's machinery (logging, saving, tools, estimates, IDs); say the same thing as a coach who simply knows",
  preamble: "it opened with filler; start with the point",
  verbose: "it was too long for a text; say it in a sentence or two",
};

async function rewriteReply(
  client: Anthropic | undefined,
  system: ReturnType<typeof coachSystemBlocks>,
  liveNote: string,
  userText: string,
  draft: string,
  violation: string,
): Promise<{ bubbles: string[]; usage: ClaudeUsage } | null> {
  try {
    const result = await callClaudeStructured({
      workload: "coach_reply_rewrite",
      model: COACH_CHAT_MODEL,
      effort: "low",
      system,
      messages: [{
        role: "user",
        content:
          `${liveNote}\n\nLuke wrote:\n${userText}\n\nYour draft reply broke a rule (${violation}${
            REWRITE_HINTS[violation] ? `: ${REWRITE_HINTS[violation]}` : ""
          }):\n${draft}\n\nRewrite the reply so it follows every rule. Use only figures from the live state. Return bubbles.`,
      }],
      schema: CHAT_REWRITE_SCHEMA,
      schemaName: "submit_reply",
      maxTokens: 4_000,
      timeoutMs: 20_000,
      client,
    });
    const object = result.output as { bubbles?: unknown };
    const bubbles = Array.isArray(object?.bubbles)
      ? object.bubbles.filter((item): item is string =>
        typeof item === "string"
      )
        .map(sanitizeCoachText).filter(Boolean)
      : [];
    return bubbles.length ? { bubbles, usage: result.usage } : null;
  } catch (error) {
    console.warn("coach_reply_rewrite_failed", {
      message: String((error as Error)?.message ?? error),
    });
    return null;
  }
}

/**
 * Runs one chat turn: manual tool loop on Sonnet (never forced tool choice;
 * assistant content appended unchanged; pause_turn continued; refusal and
 * max_tokens handled), then guard, persist, and emit.
 */
export async function runCoachTurn(
  input: CoachTurnInput,
  emit: (event: CoachStreamEvent) => void,
  dependencies: CoachTurnDependencies = {},
): Promise<CoachTurnOutcome> {
  const clock = dependencies.clock ?? Date.now;
  const deadline = clock() + (dependencies.budgetMs ?? TURN_BUDGET_MS);
  const { admin, userId, request } = input;
  const client = dependencies.client ?? claudeClient();
  // One reply row per attempt: a reclaimed run hides earlier attempts' rows.
  const replyMessageId = await deterministicUuid(`${input.claimToken}:reply`);
  const acked = { entryIds: [] as string[], activityIds: [] as string[] };
  const reply = new StreamingReply(
    admin,
    input.runId,
    input.claimToken,
    replyMessageId,
    emit,
    clock,
    () => ackedPayload(acked),
  );
  let usage = emptyUsage("coach_reply", COACH_CHAT_MODEL);
  const toolCalls: string[] = [];

  try {
    const context = await (dependencies.loadContext ?? loadCoachContext)(
      admin,
      userId,
      {
        now: input.now,
        timezone: request.timezone,
        localDay: request.localDay,
        threadLimit: HISTORY_LIMIT,
      },
    );
    const wellbeing = detectWellbeingSignal(request.text);
    const services: CoachToolServices = {
      createActivityFromText,
      researchNearbyFood,
      dispatchCoachJob,
      createTextEntry,
      mergeBioDictation,
      ...dependencies.services,
    };
    const environment: CoachToolEnvironment = {
      admin,
      userId,
      timezone: context.timezone,
      localDay: request.localDay,
      now: input.now,
      clientRequestId: request.clientRequestId,
      userMessageId: input.userMessageId,
      userText: request.text,
      location: request.location,
      context,
      allowMutations: request.text.trim().length > 0,
      client: dependencies.client,
      dispatchEntry: dependencies.dispatchEntry ?? (() => undefined),
      services,
      cards: [],
      facts: [],
      changed: new Set(),
      acked,
      runId: input.runId,
    };

    const system = coachSystemBlocks(
      context.profile.goal_type,
      COACH_CHAT_RULES,
      renderMemoryBlock(context),
    );
    const statePack = buildStatePack(context, {
      wellbeing_signal: wellbeing,
      message: {
        input_mode: request.inputMode,
        context_hint: request.contextHint,
      },
    });
    const userContent: BetaContentBlockParam[] = [];
    if (request.attachmentPath && dependencies.signedPhotoUrl) {
      const url = await dependencies.signedPhotoUrl(request.attachmentPath)
        .catch(() => null);
      if (url) userContent.push(imageFromUrl(url));
    }
    userContent.push({ type: "text", text: userTurnText(request, context) });

    const history = renderHistory(context.thread, {
      localDay: request.localDay,
      excludeIds: new Set([input.userMessageId ?? "", replyMessageId]),
    });
    const lastHistory = history.at(-1);
    const messages: BetaMessageParam[] = history.map((turn) => ({
      role: turn.role,
      content: turn.text,
    }));
    if (lastHistory?.role === "user") {
      // Two user turns in a row (an earlier message never got a reply):
      // fold them into one so roles keep alternating.
      const previous = messages.pop()!;
      userContent.unshift({ type: "text", text: String(previous.content) });
    }
    messages.push({ role: "user", content: userContent });
    // Volatile state rides as a mid-conversation system message after his
    // words, so his history and the cached prefix are never edited.
    const liveNote = liveStateNote(context, statePack, request.contextHint);
    messages.push({
      role: "system",
      content: liveNote,
    });

    const tools = [...COACH_TOOL_DEFINITIONS, webSearchTool(3)];
    const effort = chatEffort(request);
    let requests = 0;
    let pauses = 0;
    let refused = false;
    let lastResponseId: string | null = null;
    let lastModel: string = COACH_CHAT_MODEL;

    while (requests < MAX_MODEL_REQUESTS) {
      const remaining = deadline - clock() - TURN_RESERVE_MS;
      if (remaining <= 1_000) break;
      requests += 1;
      const separator = reply.body.trim().length > 0;
      let first = true;
      const stream = client.beta.messages.stream({
        ...baseParams(COACH_CHAT_MODEL, effort),
        max_tokens: 8_000,
        system,
        messages,
        tools,
        cache_control: { type: "ephemeral" },
      }, { signal: AbortSignal.timeout(remaining) });
      try {
        for await (const event of stream) {
          if (event.type === "content_block_start") {
            const block = event.content_block;
            if (block.type === "tool_use" || block.type === "server_tool_use") {
              const label = COACH_TOOL_STATUS_LABELS[block.name];
              if (label) emit({ type: "status", label });
            }
          } else if (
            event.type === "content_block_delta" &&
            event.delta.type === "text_delta"
          ) {
            let piece = event.delta.text;
            if (first && separator && piece.trim()) {
              piece = `\n\n${piece.replace(/^\s+/u, "")}`;
            }
            if (piece.trim() || !first) {
              first = false;
              reply.append(piece);
            }
          }
        }
      } catch (error) {
        stream.abort();
        throw error;
      }
      const message = await stream.finalMessage();
      const requestUsage = usageOf("coach_reply", message);
      usage = addUsage(usage, requestUsage);
      await recordCoachUsage(
        admin,
        userId,
        "coach_reply",
        requestUsage,
        input.runId,
      );
      lastResponseId = message.id ?? lastResponseId;
      lastModel = message.model ?? lastModel;

      if (message.stop_reason === "refusal") {
        refused = true;
        break;
      }
      if (message.stop_reason === "pause_turn") {
        if (pauses >= MAX_PAUSE_CONTINUATIONS) break;
        pauses += 1;
        messages.push({ role: "assistant", content: message.content });
        continue;
      }
      if (message.stop_reason !== "tool_use") break;
      const calls = message.content.filter((block) =>
        block.type === "tool_use"
      );
      if (calls.length === 0) break;
      messages.push({ role: "assistant", content: message.content });
      const results = await Promise.all(calls.map(async (call) => {
        if (call.type !== "tool_use") throw new Error("unreachable");
        if (toolCalls.length >= MAX_TOOL_CALLS) {
          return {
            type: "tool_result" as const,
            tool_use_id: call.id,
            content: JSON.stringify({
              error: "Tool budget for this message is used up.",
            }),
            is_error: true,
          };
        }
        toolCalls.push(call.name);
        const timeout = Math.min(
          COACH_TOOL_TIMEOUTS_MS[call.name] ?? DEFAULT_TOOL_TIMEOUT_MS,
          Math.max(1_000, deadline - clock() - TURN_RESERVE_MS),
        );
        const result = await withTimeout(
          executeCoachTool(call.name, call.input, environment),
          timeout,
          call.name,
        ).catch(() => ({
          content: JSON.stringify({
            error: "That took too long. Tell him to try again.",
          }),
          isError: true,
        }));
        return {
          type: "tool_result" as const,
          tool_use_id: call.id,
          content: result.content,
          ...(result.isError ? { is_error: true } : {}),
        };
      }));
      messages.push({ role: "user", content: results });
    }

    // ---- finalize: guard, persist, cards, emit
    let finalText = sanitizeCoachText(reply.body);
    let fallback: string | null = null;
    let rewritten = false;
    if (refused) {
      fallback = "refusal";
      finalText = CHAT_REFUSAL_FALLBACK;
    } else if (!finalText) {
      fallback = "empty";
      finalText = environment.cards.length > 0
        ? "Done. It's on the card."
        : CHAT_FAILURE_FALLBACK;
    }
    let bubbles = splitBubbles(finalText, 3);
    if (!fallback && bubbles.length) bubbles[0] = stripPreamble(bubbles[0]);
    const policy: CoachCopyPolicy = {
      mode: "chat_reply",
      profanity: context.settings.profanity,
      emojiAllowed: context.settings.emoji,
      allowedFigures: wellbeing
        ? []
        : allowedFiguresFor(context, ...environment.facts),
      pushCapable: false,
      longForm: wantsLongForm(request.text),
    };
    const review = fallback
      ? { safety: null, voice: null }
      : coachCopyReview({ skip: false, bubbles, push_body: null }, policy);
    // Safety problems are always rewritten (or replaced). Of the voice
    // problems only machinery is: the reply has already streamed, and
    // swapping it just to trim a sentence would read as a glitch.
    const violation = review.safety ??
      (review.voice?.code === "machinery" ? review.voice : null);
    if (violation) {
      const rewrite = deadline - clock() > 25_000
        ? await rewriteReply(
          dependencies.client,
          system,
          liveNote,
          request.text,
          finalText,
          violation.code,
        )
        : null;
      if (rewrite) {
        usage = addUsage(usage, rewrite.usage);
        await recordCoachUsage(
          admin,
          userId,
          "coach_reply",
          rewrite.usage,
          input.runId,
        );
      }
      const rewriteReview = rewrite
        ? coachCopyReview({
          skip: false,
          bubbles: rewrite.bubbles,
          push_body: null,
        }, policy)
        : null;
      if (
        rewrite && rewriteReview && !rewriteReview.safety &&
        (review.safety !== null || rewriteReview.voice?.code !== "machinery")
      ) {
        bubbles = rewrite.bubbles;
        rewritten = true;
      } else if (review.safety) {
        bubbles = [CHAT_FAILURE_FALLBACK];
        fallback = `guard:${violation.code}`;
      } else {
        console.info("coach_reply_voice_kept", { code: violation.code });
      }
    } else if (review.voice) {
      console.info("coach_reply_soft_violation", { code: review.voice.code });
    }
    const body = bubbles.join("\n\n");
    await reply.finish(body, {
      persona_version: COACH_PERSONA_VERSION,
      model: lastModel,
      input_mode: request.inputMode,
      tools: toolCalls,
      ...(request.contextHint ? { context_hint: request.contextHint } : {}),
      ...ackedPayload(acked),
      ...(rewritten ? { rewritten: true } : {}),
      ...(fallback ? { fallback } : {}),
    });

    const cards: CoachMessageInput[] = environment.cards.map((card) => ({
      ...card,
      local_day: card.local_day ?? request.localDay,
      notify: false,
      reply_to_id: input.userMessageId,
    }));
    if (wellbeing) {
      cards.push({
        kind: "text",
        body: WELLBEING_CARD_BODY,
        payload: {
          safety_flag: "wellbeing",
          resources: WELLBEING_RESOURCES,
          static: true,
        },
        local_day: request.localDay,
        notify: false,
        reply_to_id: input.userMessageId,
      });
    }
    const completion = await completeCoachRun(admin, {
      runId: input.runId,
      claimToken: input.claimToken,
      status: "complete",
      result: {
        reply_message_id: replyMessageId,
        tools: toolCalls,
        requests,
        refused,
        rewritten,
        fallback,
        changed: [...environment.changed],
        wellbeing,
        persona_version: COACH_PERSONA_VERSION,
      },
      messages: cards.slice(0, 11),
      supersedeSlotKeys: [],
      model: lastModel,
      providerResponseId: lastResponseId,
    });
    if (completion.status !== "complete") {
      throw new LostRunFenceError("Coach run was completed elsewhere");
    }

    const rows = await fetchCoachMessages(admin, userId, [
      replyMessageId,
      ...completion.message_ids,
    ]);
    for (const row of rows) emit({ type: "message", message: row });
    emit({
      type: "done",
      run_id: input.runId,
      message_ids: rows.map((row) => row.id),
    });

    if (
      environment.changed.has("goals") || environment.changed.has("bio") ||
      environment.changed.has("weight")
    ) {
      dependencies.schedulePlan?.({
        job: "plan",
        user_id: userId,
        payload: { trigger: "chat", foreground: true },
      });
    }
    return {
      status: "complete",
      replyMessageId,
      messageIds: rows.map((row) => row.id),
      text: body,
      toolCalls,
      usage,
    };
  } catch (error) {
    const lost = error instanceof LostRunFenceError;
    const message = error instanceof Error ? error.message : String(error);
    console.error("coach_turn_failed", {
      userId,
      lost,
      message: message.slice(0, 300),
    });
    // An empty Anthropic balance is not a hiccup; say what's wrong instead
    // of inviting retries that can't succeed.
    const failureText = isClaudeBillingError(error)
      ? CLAUDE_BILLING_MESSAGE
      : CHAT_FAILURE_FALLBACK;
    if (!lost) {
      await reply.finish(
        reply.body.trim()
          ? `${sanitizeCoachText(reply.body)}\n\n${failureText}`
          : failureText,
        { persona_version: COACH_PERSONA_VERSION, fallback: "failed" },
      ).catch(() => undefined);
      await failCoachRun(admin, input.runId, input.claimToken, message).catch(
        () => undefined,
      );
    }
    emit({
      type: "error",
      code: lost
        ? "superseded"
        : isClaudeBillingError(error)
        ? "ai_credits"
        : "turn_failed",
      message: failureText,
      retryable: !lost,
    });
    return {
      status: lost ? "stale" : "failed",
      replyMessageId,
      messageIds: [],
      text: "",
      toolCalls,
      usage,
    };
  }
}

// ----------------------------------------------------- replay / tail

async function runMessages(
  admin: SupabaseClient,
  userId: string,
  runId: string,
): Promise<CoachMessageRow[]> {
  const { data, error } = await admin.from("coach_messages")
    .select(COACH_MESSAGE_COLUMNS)
    .eq("user_id", userId)
    .eq("run_id", runId)
    .order("deliver_at", { ascending: true })
    .limit(20);
  if (error) throw error;
  return (data ?? []) as CoachMessageRow[];
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/// A resend of a running turn: re-read the reply row and forward only the
/// characters the client hasn't seen, until the run itself is finished.
export async function tailCoachRun(
  admin: SupabaseClient,
  userId: string,
  runId: string,
  emit: (event: CoachStreamEvent) => void,
  options: { maxMs?: number; intervalMs?: number; clock?: () => number } = {},
): Promise<void> {
  const clock = options.clock ?? Date.now;
  const stopAt = clock() + (options.maxMs ?? TURN_BUDGET_MS);
  const sent = new Map<string, string>();
  while (clock() < stopAt) {
    const [run] = await getCoachRuns(admin, { userId, runId, limit: 1 });
    const rows = (await runMessages(admin, userId, runId))
      .filter((row) => row.status !== "superseded");
    for (const row of rows) {
      if (row.payload?.streaming !== true) continue;
      const previous = sent.get(row.id) ?? "";
      if (row.body.startsWith(previous) && row.body.length > previous.length) {
        emit({
          type: "delta",
          message_id: row.id,
          text: row.body.slice(previous.length),
        });
        sent.set(row.id, row.body);
      }
    }
    if (!run || run.status === "complete" || run.status === "skipped") {
      for (const row of rows) emit({ type: "message", message: row });
      emit({
        type: "done",
        run_id: runId,
        message_ids: rows.map((row) => row.id),
      });
      return;
    }
    if (run.status === "failed" || !run.live) {
      for (const row of rows) emit({ type: "message", message: row });
      emit({
        type: "error",
        code: "turn_failed",
        message: CHAT_FAILURE_FALLBACK,
        retryable: true,
      });
      return;
    }
    await delay(options.intervalMs ?? STREAM_WRITE_INTERVAL_MS);
  }
  emit({
    type: "error",
    code: "still_running",
    message: "Still working on that. Pull to refresh in a moment.",
    retryable: true,
  });
}

// ------------------------------------------------------------ handler

export type CoachChatDependencies = CoachTurnDependencies & {
  observe: (promise: Promise<unknown>) => void;
  now?: () => Date;
  keepaliveMs?: number;
  logMealText?: (
    admin: SupabaseClient,
    userId: string,
    description: string,
    clientRequestId: string,
    timezone: string,
  ) => Promise<string>;
};

function claimError(status: string): HttpError {
  switch (status) {
    case "capacity":
      return new HttpError(
        429,
        "The coach is still on your last few messages. Try again in a moment.",
      );
    case "exhausted":
      return new HttpError(
        409,
        "That message couldn't be answered. Send it again as a new message.",
      );
    default:
      return new HttpError(409, "That message conflicts with an earlier one.");
  }
}

export function quotaHttpError(error: unknown): HttpError | null {
  const mapped = modelQuotaHttpError(error);
  if (mapped) return mapped;
  const message = String((error as { message?: string })?.message ?? error);
  if (message.includes("project_ai_spend_exceeded")) {
    return new HttpError(
      429,
      "The shared beta AI limit has been reached. Try again later.",
    );
  }
  return null;
}

/// Handles a send: store the user message, claim the reply run, and either
/// run, tail, or replay it, streaming SSE back.
export async function startCoachSend(
  admin: SupabaseClient,
  userId: string,
  request: CoachSendRequest,
  dependencies: CoachChatDependencies,
): Promise<Response> {
  validateAttachmentPath(userId, request.attachmentPath);
  const now = dependencies.now?.() ?? new Date();
  const posted = await postUserCoachMessage(admin, {
    userId,
    clientRequestId: request.clientRequestId,
    localDay: request.localDay,
    kind: request.attachmentPath ? "photo" : "text",
    body: request.text,
    payload: {
      input_mode: request.inputMode,
      ...(request.speechEngine ? { speech_engine: request.speechEngine } : {}),
      ...(request.contextHint ? { context_hint: request.contextHint } : {}),
    },
    attachmentPath: request.attachmentPath,
  });
  if (posted.status === "conflict") {
    throw new HttpError(
      409,
      "That message id was already used for a different message.",
    );
  }
  if (posted.status === "quota") {
    throw new HttpError(
      429,
      "That's a lot of messages today. Try again later.",
    );
  }
  let claim;
  try {
    claim = await claimCoachRun(admin, {
      userId,
      operation: "coach_reply",
      localDay: request.localDay,
      checkpointKey: `reply:${request.clientRequestId}`,
      triggerSource: "user",
      scheduledFor: now,
      leaseSeconds: 150,
    });
  } catch (error) {
    throw quotaHttpError(error) ?? error;
  }
  if (claim.status === "quota") {
    throw new HttpError(
      429,
      "The coach is out of thinking time for today. Try again later.",
    );
  }
  if (!claim.run_id) throw claimError(claim.status);
  const runId = claim.run_id;
  const userMessage = posted.message ??
    (posted.message_id
      ? (await fetchCoachMessages(admin, userId, [posted.message_id]))[0]
      : null);

  const channel = new SseChannel(dependencies.keepaliveMs);
  const emit = (event: CoachStreamEvent) => channel.send(event);
  const duplicate = posted.status === "existing" || !isClaimed(claim) ||
    claim.status === "reclaimed";
  emit({
    type: "accepted",
    run_id: runId,
    user_message: userMessage ?? null,
    duplicate,
  });

  let work: Promise<unknown>;
  if (isClaimed(claim)) {
    work = runCoachTurn(
      {
        admin,
        userId,
        runId,
        claimToken: claim.claim_token,
        request,
        userMessageId: posted.message_id,
        now,
      },
      emit,
      {
        ...dependencies,
        dispatchEntry: dependencies.dispatchEntry,
        schedulePlan: dependencies.schedulePlan,
      },
    );
  } else if (claim.status === "complete" || claim.status === "skipped") {
    work = runMessages(admin, userId, runId).then((rows) => {
      for (const row of rows) emit({ type: "message", message: row });
      emit({
        type: "done",
        run_id: runId,
        message_ids: rows.map((row) => row.id),
      });
    });
  } else if (claim.status === "running") {
    work = tailCoachRun(admin, userId, runId, emit);
  } else {
    const error = claimError(claim.status);
    emit({
      type: "error",
      code: claim.status,
      message: error.message,
      retryable: claim.status === "capacity",
    });
    work = Promise.resolve();
  }
  dependencies.observe(
    work.catch((error) => {
      console.error("coach_chat_stream_failed", { message: String(error) });
      emit({
        type: "error",
        code: "stream_failed",
        message: CHAT_FAILURE_FALLBACK,
        retryable: true,
      });
    }).finally(() => channel.close()),
  );
  return channel.response;
}

export async function runCardAction(
  admin: SupabaseClient,
  userId: string,
  body: Extract<CoachChatBody, { kind: "action" }>,
  dependencies: CoachChatDependencies,
  timezone: string,
): Promise<CoachMessageRow[]> {
  return await handleCardAction(admin, userId, body.action, {
    now: dependencies.now,
    refreshPlan: () =>
      dependencies.schedulePlan?.({
        job: "plan",
        user_id: userId,
        payload: { trigger: "settings", foreground: true },
      }),
    logMealText: dependencies.logMealText
      ? (description, seed) =>
        dependencies.logMealText!(admin, userId, description, seed, timezone)
      : undefined,
  });
}
