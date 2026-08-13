import 'server-only'

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/types/database'

const MEAL_IMAGE_BUCKET = 'entry-images'
const SIGNED_URL_TTL_SECONDS = 60 * 60

/**
 * Batch-sign private meal-photo paths under the caller's RLS session. Paths
 * that fail to sign are simply absent from the map — a missing thumbnail
 * must never take down the page.
 */
export async function createSignedImageUrls(
  supabase: SupabaseClient<Database>,
  paths: (string | null | undefined)[],
): Promise<Map<string, string>> {
  const uniquePaths = Array.from(new Set(paths.filter((path): path is string => Boolean(path))))
  if (uniquePaths.length === 0) return new Map()

  const { data, error } = await supabase.storage
    .from(MEAL_IMAGE_BUCKET)
    .createSignedUrls(uniquePaths, SIGNED_URL_TTL_SECONDS)

  if (error || !data) return new Map()

  const urls = new Map<string, string>()
  for (const entry of data) {
    if (entry.path && entry.signedUrl && !entry.error) {
      urls.set(entry.path, entry.signedUrl)
    }
  }
  return urls
}
