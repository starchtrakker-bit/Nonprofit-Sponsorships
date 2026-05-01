import { cache } from 'react'
import { createClient } from '@/lib/supabase/server'

// React's cache() dedupes calls within a single server render pass.
// Layouts + pages both invoke this; the second call returns the first
// call's Promise instead of re-running auth + the users-row lookup.
//
// If your `users` table has a different shape, adjust the .select() to
// match the columns you actually need across pages.
export const getCurrentUser = cache(async () => {
  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()

  if (!user) {
    return { supabase, user: null, userRecord: null as null }
  }

  // TODO: adjust columns to match your users table schema
  const { data: userRecord } = await supabase
    .from('users')
    .select('*')
    .eq('auth_user_id', user.id)
    .single()

  return { supabase, user, userRecord }
})
