import "jsr:@supabase/functions-js@2.110.7/edge-runtime.d.ts";
import {
  analyzeOnboarding,
  localDayInTimezone,
  mergeOnboardingValues,
  ONBOARDING_MODEL,
  ONBOARDING_PROCESSING_BUDGET_MS,
  parseOnboardingCapture,
  transcribeOnboardingAudio,
} from "../_shared/onboarding.ts";
import {
  authenticate,
  CORS_HEADERS,
  HttpError,
  isUuid,
  json,
} from "../_shared/http.ts";
import { modelQuotaHttpError } from "../_shared/quotas.ts";

type StoredOnboarding = {
  id: string;
  transcript: string | null;
  timezone_snapshot: string;
  recommendation: unknown;
  final_values: unknown;
  status: "analyzing" | "proposed" | "applied" | "failed";
  generation_attempt: number;
  lease_expires_at: string | null;
  claimed?: boolean;
};

type OnboardingClaim = Omit<StoredOnboarding, "id"> & {
  onboarding_id: string;
  claimed: boolean;
};

const ONBOARDING_FIELDS =
  "id,transcript,timezone_snapshot,recommendation,final_values,status,generation_attempt,lease_expires_at";

Deno.serve(async (req: Request) => {
  const processingDeadline = Date.now() + ONBOARDING_PROCESSING_BUDGET_MS;
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  let userId = "";
  try {
    const context = await authenticate(req);
    userId = context.userId;
    const mediaType = req.headers.get("content-type")?.split(";", 1)[0]
      .trim().toLowerCase();

    if (mediaType === "application/json") {
      const payload = await req.json().catch(() => null);
      if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
        throw new HttpError(400, "Request body must be a JSON object");
      }
      const object = payload as Record<string, unknown>;
      const onboardingId = typeof object.onboarding_id === "string"
        ? object.onboarding_id.trim().toLowerCase()
        : "";
      if (!isUuid(onboardingId)) {
        throw new HttpError(400, "onboarding_id must be a UUID");
      }
      const { data, error } = await context.admin.from("onboarding_analyses")
        .select(ONBOARDING_FIELDS)
        .eq("id", onboardingId)
        .eq("user_id", userId)
        .maybeSingle();
      if (error) throw error;
      if (!data) throw new HttpError(404, "Onboarding proposal not found");
      const onboarding = data as StoredOnboarding;
      if (onboarding.status === "applied") {
        return json({
          onboarding_id: onboarding.id,
          status: "applied",
          final_profile: onboarding.final_values,
        });
      }
      if (onboarding.status !== "proposed") {
        throw new HttpError(
          409,
          onboarding.status === "analyzing"
            ? "Your onboarding profile is still being prepared."
            : "This onboarding attempt did not finish. Start a new voice setup.",
        );
      }
      const finalValues = mergeOnboardingValues(
        onboarding.recommendation,
        object.overrides,
        onboarding.timezone_snapshot,
      );
      const { data: applied, error: applyError } = await context.admin.rpc(
        "apply_onboarding_profile",
        {
          p_onboarding_id: onboarding.id,
          p_user_id: userId,
          p_target_day: localDayInTimezone(new Date(), finalValues.timezone),
          p_values: finalValues,
        },
      );
      if (applyError) throw applyError;
      if (applied !== true) {
        throw new HttpError(
          409,
          "This onboarding proposal was already changed",
        );
      }
      return json({
        onboarding_id: onboarding.id,
        status: "applied",
        final_profile: finalValues,
      });
    }

    if (mediaType !== "multipart/form-data") {
      throw new HttpError(415, "Expected multipart form data or JSON");
    }
    const capture = parseOnboardingCapture(await req.formData());
    // The database claim owns quota, concurrency, stale-lease recovery, and
    // replay fencing before either billable OpenAI call.
    const { data: claimData, error: claimError } = await context.admin.rpc(
      "claim_onboarding_analysis",
      {
        p_user_id: userId,
        p_client_request_id: capture.clientRequestId,
        p_timezone_snapshot: capture.timezone,
        p_analysis_model: ONBOARDING_MODEL,
      },
    );
    if (claimError) throw modelQuotaHttpError(claimError) ?? claimError;
    const rawClaim = Array.isArray(claimData)
      ? claimData[0] as OnboardingClaim | undefined
      : undefined;
    if (!rawClaim) throw new Error("Could not reserve onboarding analysis");
    const reserved: StoredOnboarding = {
      ...rawClaim,
      id: rawClaim.onboarding_id,
    };
    if (reserved.claimed !== true) {
      return json({
        onboarding_id: reserved.id,
        status: reserved.status,
        transcript: reserved.transcript,
        recommendation: reserved.recommendation,
        final_profile: reserved.final_values,
        duplicate: true,
      }, reserved.status === "analyzing" ? 202 : 200);
    }

    try {
      const audioTranscript = capture.audio
        ? await transcribeOnboardingAudio(capture.audio, processingDeadline)
        : "";
      const transcript = [capture.text, audioTranscript].filter(Boolean).join(
        "\n",
      )
        .trim().slice(0, 30_000);
      const analyzed = await analyzeOnboarding(
        userId,
        transcript,
        processingDeadline,
      );
      const { data: stored, error: updateError } = await context.admin
        .from("onboarding_analyses")
        .update({
          transcript,
          recommendation: analyzed.recommendation,
          provider_response_id: analyzed.responseId,
          status: "proposed",
          lease_expires_at: null,
          error_message: null,
        })
        .eq("id", reserved.id)
        .eq("user_id", userId)
        .eq("status", "analyzing")
        .eq("generation_attempt", reserved.generation_attempt)
        .select(ONBOARDING_FIELDS)
        .maybeSingle();
      if (updateError) throw updateError;
      if (!stored) throw new Error("Onboarding reservation was replaced");
      const result = stored as StoredOnboarding;
      return json({
        onboarding_id: result.id,
        status: result.status,
        transcript: result.transcript,
        recommendation: result.recommendation,
        final_profile: result.final_values,
        duplicate: false,
      }, 201);
    } catch (processingError) {
      await context.admin.from("onboarding_analyses").update({
        status: "failed",
        lease_expires_at: null,
        error_message: String(processingError).slice(0, 500),
      }).eq("id", reserved.id).eq("user_id", userId).eq("status", "analyzing")
        .eq("generation_attempt", reserved.generation_attempt);
      throw processingError;
    }
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500;
    const message = error instanceof HttpError
      ? error.message
      : "Could not finish onboarding. Please try again.";
    if (status >= 500) {
      console.error("onboard_profile_failed", {
        userId,
        message: String(error),
      });
    }
    return json({ error: message }, status);
  }
});
