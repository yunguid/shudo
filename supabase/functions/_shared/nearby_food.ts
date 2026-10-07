// PLACEHOLDER: replaced by lane B3. Only the SPEC §4 types and signatures
// exist here so the coach brain (lane B2) compiles; research fails until B3
// merges.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";

export type NearbyStore = {
  ref: string;
  name: string;
  category: string;
  distance_m: number;
  walk_minutes: number;
  walk_minutes_source: "mapkit_eta" | "estimate";
  address_short?: string | null;
};

export type LocationContext = {
  captured_at: string;
  quality: "precise" | "approximate" | "none";
  locality: {
    neighborhood?: string | null;
    city?: string | null;
    region?: string | null;
    country?: string | null;
    timezone: string;
  };
  stores: NearbyStore[];
};

type MacroTotals = {
  calories_kcal: number;
  protein_g: number;
  carbs_g: number;
  fat_g: number;
};

export type SnackRecPayload = {
  headline: string;
  verdict: "grab" | "no_snack_needed";
  options: Array<{
    store_ref: string;
    store_name: string;
    walk_minutes: number;
    items: Array<{
      name: string;
      brand?: string | null;
      serving: string;
      quantity: number;
      calories_kcal: number;
      protein_g: number;
      carbs_g: number;
      fat_g: number;
      price_usd_est?: number | null;
      source_url?: string | null;
      nutrition_source: "web" | "label_known" | "estimate";
    }>;
    combined: MacroTotals;
    remaining_after: MacroTotals;
    maps_query: string;
  }>;
  sources: string[];
};

export function researchNearbyFood(
  _admin: SupabaseClient,
  _userId: string,
  _input: {
    localDay: string;
    timezone: string;
    localTime: string;
    location: LocationContext | null;
    query: string | null;
    remaining: MacroTotals;
  },
): Promise<SnackRecPayload> {
  return Promise.reject(new Error("Nearby food research is not available yet"));
}
