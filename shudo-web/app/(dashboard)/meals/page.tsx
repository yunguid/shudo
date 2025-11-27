import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'
import { Card, CardContent } from '@/components/ui/card'
import { fetchAllEntries } from '@/lib/supabase/queries'
import { UtensilsCrossed } from 'lucide-react'
import { MealsTable } from './table'

interface MealsPageProps {
  searchParams: Promise<{ page?: string }>
}

export default async function MealsPage({ searchParams }: MealsPageProps) {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()

  if (!user) {
    redirect('/auth/login')
  }

  const params = await searchParams
  const page = parseInt(params.page || '1', 10)
  const limit = 25
  const offset = (page - 1) * limit

  const { entries, total } = await fetchAllEntries(supabase, user.id, { limit, offset })
  const totalPages = Math.ceil(total / limit)

  return (
    <div className="min-h-screen">
      <div className="p-6">
        <div className="flex items-baseline justify-between mb-4">
          <h1 className="text-lg font-semibold text-ink">Meals</h1>
          <span className="text-xs text-muted">{total} entries</span>
        </div>

        <Card>
          <CardContent className="p-0">
            {entries.length > 0 ? (
              <MealsTable entries={entries} page={page} totalPages={totalPages} />
            ) : (
              <div className="flex flex-col items-center justify-center py-16 text-center">
                <div className="flex h-12 w-12 items-center justify-center rounded-xl bg-elevated mb-3">
                  <UtensilsCrossed className="h-6 w-6 text-muted" />
                </div>
                <p className="text-sm text-muted">No meals logged yet</p>
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  )
}



