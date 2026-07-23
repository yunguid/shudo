/**
 * Stable per-user pseudonymous identifier forwarded to OpenAI as
 * `safety_identifier`. A truncated SHA-256 keeps the real user id private
 * while remaining consistent across that user's requests.
 */
export async function safetyIdentifier(userId: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(userId),
  );
  return `shudo_${
    Array.from(new Uint8Array(digest)).slice(0, 16).map((byte) =>
      byte.toString(16).padStart(2, "0")
    ).join("")
  }`;
}
