import { HttpError } from "./errors.ts";
import { isUuid } from "./http.ts";

export const MAX_REANALYSIS_CONTEXT_CHARACTERS = 4_000;

export type ReanalysisRequest = {
  entryId: string;
  context: string;
};

export function parseReanalysisRequest(payload: unknown): ReanalysisRequest {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new HttpError(400, "Request body must be a JSON object");
  }
  const object = payload as Record<string, unknown>;
  const entryId = typeof object.entry_id === "string"
    ? object.entry_id.trim().toLowerCase()
    : "";
  const context = typeof object.context === "string"
    ? object.context.trim()
    : "";
  if (!isUuid(entryId)) {
    throw new HttpError(400, "entry_id must be a lowercase UUID");
  }
  if (!context) throw new HttpError(400, "context is required");
  if (Array.from(context).length > MAX_REANALYSIS_CONTEXT_CHARACTERS) {
    throw new HttpError(413, "context must be 4000 characters or fewer");
  }
  return { entryId, context };
}
