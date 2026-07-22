import { HttpError } from "./errors.ts";

export function modelQuotaHttpError(error: unknown): HttpError | null {
  const message = error && typeof error === "object" &&
      "message" in error && typeof error.message === "string"
    ? error.message
    : String(error);
  if (message.includes("project_ai_budget_exceeded")) {
    return new HttpError(
      429,
      "The shared beta AI limit has been reached. Try again later.",
    );
  }
  if (message.includes("entry_daily_quota_exceeded")) {
    return new HttpError(
      429,
      "You’ve reached the 30-meal limit for the last 24 hours. Try again later.",
    );
  }
  if (message.includes("entry_request_already_consumed")) {
    return new HttpError(
      409,
      "That meal request was already used. Start a new capture.",
    );
  }
  if (message.includes("entry_concurrency_quota_exceeded")) {
    return new HttpError(
      429,
      "A few meals are still processing. Let one finish, then try again.",
    );
  }
  if (message.includes("onboarding_daily_quota_exceeded")) {
    return new HttpError(
      429,
      "You’ve reached today’s onboarding limit. Try again tomorrow.",
    );
  }
  if (message.includes("onboarding_concurrency_quota_exceeded")) {
    return new HttpError(
      409,
      "Your onboarding profile is already being prepared.",
    );
  }
  return null;
}
