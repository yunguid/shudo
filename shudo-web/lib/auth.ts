import 'server-only'

import { cache } from 'react'
import { createServerSupabaseClient } from '@/lib/supabase/server'

export const getCurrentUser = cache(async () => {
  const supabase = await createServerSupabaseClient()
  const { data, error } = await supabase.auth.getUser()

  if (error) {
    if (error.status === 400 || error.status === 401 || error.status === 403) {
      return null
    }

    throw new Error('Unable to verify the current session.', { cause: error })
  }

  return data.user
})
