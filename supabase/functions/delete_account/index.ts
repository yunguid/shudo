import "jsr:@supabase/functions-js@2.110.7/edge-runtime.d.ts";
import {
  accountDeletionFailureMessage,
  deleteAccountStorage,
  requireAccountDeletionConfirmation,
} from "../_shared/account_deletion.ts";
import {
  authenticate,
  CORS_HEADERS,
  HttpError,
  json,
} from "../_shared/http.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  let userId = "";
  let storageDeletionStarted = false;
  try {
    const context = await authenticate(req);
    userId = context.userId;
    requireAccountDeletionConfirmation(await req.json().catch(() => null));

    // Auth will refuse hard deletion while the user owns Storage objects.
    // Remove both current and restored-legacy prefixes before deleting the
    // auth.users row; its database dependents then cascade in one transaction.
    storageDeletionStarted = true;
    const removedObjects = await deleteAccountStorage(context.admin, userId);
    const { error } = await context.admin.auth.admin.deleteUser(userId);
    if (error) throw error;

    return json({ deleted: true, removed_objects: removedObjects });
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500;
    const message = error instanceof HttpError
      ? error.message
      : accountDeletionFailureMessage(storageDeletionStarted);
    if (status >= 500) {
      console.error("delete_account_failed", {
        userId,
        message: String(error),
      });
    }
    return json({ error: message }, status);
  }
});
