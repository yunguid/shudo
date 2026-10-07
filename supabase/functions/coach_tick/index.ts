import "jsr:@supabase/functions-js@2.110.7/edge-runtime.d.ts";
import {
  defaultCoachTickDependencies,
  handleCoachTick,
} from "../_shared/coach_tick.ts";

/// Maintenance-only (verify_jwt=false): authenticated by the existing
/// x-shudo-weekly-secret header. See _shared/coach_tick.ts.
const dependencies = defaultCoachTickDependencies();

Deno.serve((req: Request) => handleCoachTick(req, dependencies));
