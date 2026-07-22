import { isUuid } from "../_shared/http.ts";

export const CORRECTION_RESERVATION_STATUSES = [
  "reserved",
  "reclaimed",
  "complete",
  "processing",
  "not_found",
  "busy",
  "unavailable",
  "quota",
  "capacity",
  "failed",
  "conflict",
] as const;

export type CorrectionReservationStatus =
  (typeof CORRECTION_RESERVATION_STATUSES)[number];

type CorrectionOwnedReservationStatus = "reserved" | "reclaimed";
type CorrectionUnownedReservationStatus = Exclude<
  CorrectionReservationStatus,
  CorrectionOwnedReservationStatus
>;

export type CorrectionReservation =
  | { status: CorrectionOwnedReservationStatus; claimToken: string }
  | { status: CorrectionUnownedReservationStatus; claimToken: null };

const correctionReservationStatusSet = new Set<string>(
  CORRECTION_RESERVATION_STATUSES,
);

export function parseCorrectionReservation(
  value: unknown,
): CorrectionReservation {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("Correction reservation response was invalid");
  }

  const payload = value as Record<string, unknown>;
  if (
    typeof payload.status !== "string" ||
    !correctionReservationStatusSet.has(payload.status)
  ) {
    throw new Error("Correction reservation status was invalid");
  }

  const status = payload.status as CorrectionReservationStatus;
  if (status === "reserved" || status === "reclaimed") {
    if (
      typeof payload.claim_token !== "string" || !isUuid(payload.claim_token)
    ) {
      throw new Error("Correction reservation claim token was invalid");
    }
    return { status, claimToken: payload.claim_token.toLowerCase() };
  }

  return {
    status: status as CorrectionUnownedReservationStatus,
    claimToken: null,
  };
}
