export type OwnerIdentity = {
  id: string;
  email?: string | null;
};

export type OwnerAccess = "allowed" | "denied" | "missing_policy";

export function hasOwnerPolicy(
  configuredUserId?: string | null,
  configuredEmail?: string | null,
): boolean {
  return Boolean(configuredUserId?.trim() || configuredEmail?.trim());
}

/**
 * Evaluates the single-owner policy without trusting JWT metadata. When both
 * an id and email are configured they must both match, which lets operators
 * tighten access during account migrations.
 */
export function evaluateOwnerAccess(
  user: OwnerIdentity,
  configuredUserId?: string | null,
  configuredEmail?: string | null,
): OwnerAccess {
  const ownerUserId = configuredUserId?.trim() ?? "";
  const ownerEmail = configuredEmail?.trim().toLowerCase() ?? "";
  if (!hasOwnerPolicy(ownerUserId, ownerEmail)) return "missing_policy";
  if (ownerUserId && user.id !== ownerUserId) return "denied";
  if (ownerEmail && user.email?.trim().toLowerCase() !== ownerEmail) {
    return "denied";
  }
  return "allowed";
}
