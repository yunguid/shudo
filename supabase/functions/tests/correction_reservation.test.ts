import { parseCorrectionReservation } from "../correct_entry/reservation.ts";
import { assertEquals, assertThrows } from "./assertions.ts";

const CLAIM_TOKEN = "10000000-0000-4000-8000-000000000001";

Deno.test("correction reservation parser returns the owned claim token", () => {
  assertEquals(
    parseCorrectionReservation({
      status: "reserved",
      claim_token: CLAIM_TOKEN.toUpperCase(),
    }),
    { status: "reserved", claimToken: CLAIM_TOKEN },
  );
  assertEquals(
    parseCorrectionReservation({
      status: "reclaimed",
      claim_token: CLAIM_TOKEN,
    }),
    { status: "reclaimed", claimToken: CLAIM_TOKEN },
  );
});

Deno.test("correction reservation parser accepts terminal and blocked states", () => {
  assertEquals(
    parseCorrectionReservation({ status: "complete" }),
    { status: "complete", claimToken: null },
  );
  assertEquals(
    parseCorrectionReservation({ status: "quota" }),
    { status: "quota", claimToken: null },
  );
});

Deno.test("correction reservation parser rejects malformed RPC contracts", () => {
  assertThrows(() => parseCorrectionReservation("reserved"));
  assertThrows(() => parseCorrectionReservation({ status: "unknown" }));
  assertThrows(() => parseCorrectionReservation({ status: "reserved" }));
  assertThrows(() =>
    parseCorrectionReservation({
      status: "reclaimed",
      claim_token: "not-a-uuid",
    })
  );
});
