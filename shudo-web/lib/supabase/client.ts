import { createBrowserClient } from '@supabase/ssr'
import type { SupabaseClient } from '@supabase/supabase-js'
import { getSupabasePublicConfig } from '@/lib/supabase/config'
import type { Database } from '@/types/database'

let browserClient: SupabaseClient<Database> | undefined

export function getBrowserClient(): SupabaseClient<Database> {
  if (!browserClient) {
    const { url, key } = getSupabasePublicConfig()
    browserClient = createBrowserClient<Database>(url, key)
  }

  return browserClient
}
