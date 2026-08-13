import type { Metadata } from 'next'
import Link from 'next/link'
import { ChevronLeft } from 'lucide-react'
import { notFound, redirect } from 'next/navigation'
import { parseAnalysisItems } from '@/lib/analysis'
import { getCurrentUser } from '@/lib/auth'
import {
  fetchEntryDetail,
  fetchEntryPhotos,
  fetchProfileSettings,
  summarizeEntry,
} from '@/lib/supabase/queries'
import { createServerSupabaseClient } from '@/lib/supabase/server'
import { createSignedImageUrls } from '@/lib/supabase/storage'
import { formatDayLabel, formatEntryTime, resolveEntryTimestamp } from '@/lib/utils'

export const metadata: Metadata = {
  title: 'Meal',
}

interface MealDetailPageProps {
  params: Promise<{ id: string }>
}

export default async function MealDetailPage({ params }: MealDetailPageProps) {
  const user = await getCurrentUser()
  if (!user) redirect('/auth/login')

  const { id } = await params
  const supabase = await createServerSupabaseClient()
  const [profile, entry] = await Promise.all([
    fetchProfileSettings(supabase, user.id),
    fetchEntryDetail(supabase, user.id, id),
  ])
  if (!entry) notFound()

  const extraPhotos = await fetchEntryPhotos(supabase, user.id, entry.id)
  const photoPaths = [
    entry.image_path,
    ...extraPhotos
      .map((photo) => photo.storage_path)
      .filter((path) => path !== entry.image_path),
  ].filter((path): path is string => Boolean(path))
  const photoUrls = await createSignedImageUrls(supabase, photoPaths)
  const orderedPhotoUrls = photoPaths
    .map((path) => photoUrls.get(path))
    .filter((url): url is string => Boolean(url))
  const [primaryPhoto, ...morePhotos] = orderedPhotoUrls

  const items = parseAnalysisItems(entry.items)
  const spokenEntry = entry.transcript?.trim() || entry.raw_text?.trim() || null
  const timestamp = resolveEntryTimestamp(entry.occurred_at, entry.created_at)
  const macroMetrics = [
    { label: 'Protein', value: entry.protein_g, color: 'text-protein' },
    { label: 'Carbs', value: entry.carbs_g, color: 'text-carbs' },
    { label: 'Fat', value: entry.fat_g, color: 'text-fat' },
  ] as const

  return (
    <div className="space-y-7">
      <header>
        <Link
          className="inline-flex min-h-11 items-center gap-1 rounded-xl px-2 py-2 text-xs font-medium text-accent transition hover:bg-accent/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
          href={`/?day=${entry.local_day}`}
        >
          <ChevronLeft aria-hidden="true" className="h-3.5 w-3.5" />
          {formatDayLabel(entry.local_day, true)}
        </Link>
        <h1 className="mt-3 text-3xl font-semibold tracking-tight text-ink">{summarizeEntry(entry)}</h1>
        <p className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-muted">
          <time dateTime={timestamp}>{formatEntryTime(timestamp, profile.timezone)}</time>
          {typeof entry.confidence === 'number' ? (
            <span className="rounded-full bg-surface-strong px-2.5 py-0.5 font-mono text-[11px] text-subtle">
              {Math.round(entry.confidence * 100)}% confidence
            </span>
          ) : null}
        </p>
      </header>

      {primaryPhoto ? (
        <figure className="space-y-3">
          <img
            alt={`Photo of ${summarizeEntry(entry)}`}
            className="max-h-[28rem] w-full rounded-[1.75rem] bg-surface object-cover shadow-2xl shadow-black/25"
            decoding="async"
            src={primaryPhoto}
          />
          {morePhotos.length ? (
            <div className="grid grid-cols-3 gap-3 sm:grid-cols-4">
              {morePhotos.map((url) => (
                <img
                  alt="Additional meal photo"
                  className="aspect-square w-full rounded-2xl bg-surface object-cover"
                  decoding="async"
                  key={url}
                  loading="lazy"
                  src={url}
                />
              ))}
            </div>
          ) : null}
        </figure>
      ) : null}

      <section aria-labelledby="meal-macros-heading" className="rounded-[2rem] bg-surface/75 p-6 shadow-2xl shadow-black/20 sm:p-8">
        <h2 className="sr-only" id="meal-macros-heading">Meal totals</h2>
        <div className="flex flex-col justify-between gap-8 sm:flex-row sm:items-end">
          <div>
            <p className="text-xs font-medium uppercase tracking-[0.18em] text-muted">Energy</p>
            <p className="mt-3 flex items-baseline gap-2">
              <span className="font-mono text-5xl font-medium tracking-[-0.06em] text-ink">
                {Math.round(entry.calories_kcal).toLocaleString()}
              </span>
              <span className="text-sm text-muted">kcal</span>
            </p>
          </div>
          <dl className="grid grid-cols-3 gap-7 sm:gap-10">
            {macroMetrics.map((macro) => (
              <div key={macro.label}>
                <dt className="text-xs text-muted">{macro.label}</dt>
                <dd className={`mt-1 font-mono text-xl font-medium ${macro.color}`}>
                  {Math.round(macro.value)}g
                </dd>
              </div>
            ))}
          </dl>
        </div>
      </section>

      {items.length ? (
        <section aria-labelledby="meal-items-heading">
          <h2 className="mb-3 px-1 text-sm font-medium text-ink" id="meal-items-heading">
            Breakdown
          </h2>
          <ul className="overflow-hidden rounded-[1.75rem] bg-surface/60">
            {items.map((item, index) => (
              <li className="flex items-center gap-4 px-5 py-4" key={`${item.name}-${index}`}>
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm text-ink">{item.name}</p>
                  {item.amount ? <p className="mt-1 text-xs text-subtle">{item.amount}</p> : null}
                </div>
                <div className="flex shrink-0 items-baseline gap-3 text-right font-mono text-xs">
                  <span className="text-sm text-ink">{Math.round(item.calories_kcal)}</span>
                  <span className="text-protein">{Math.round(item.protein_g)}g</span>
                  <span className="text-carbs">{Math.round(item.carbs_g)}g</span>
                  <span className="text-fat">{Math.round(item.fat_g)}g</span>
                </div>
              </li>
            ))}
          </ul>
          <p aria-hidden="true" className="mt-2 px-2 text-right text-[10px] uppercase tracking-[0.14em] text-subtle">
            kcal · protein · carbs · fat
          </p>
        </section>
      ) : null}

      {entry.analysis_notes ? (
        <section aria-labelledby="meal-notes-heading" className="rounded-[1.75rem] bg-surface/60 px-6 py-5">
          <h2 className="text-xs font-medium uppercase tracking-[0.18em] text-muted" id="meal-notes-heading">
            Analysis notes
          </h2>
          <p className="mt-3 text-sm leading-6 text-muted">{entry.analysis_notes}</p>
        </section>
      ) : null}

      {spokenEntry ? (
        <details className="group rounded-[1.75rem] bg-surface/60 px-6 py-5">
          <summary className="cursor-pointer list-none text-xs font-medium uppercase tracking-[0.18em] text-muted transition group-open:text-ink [&::-webkit-details-marker]:hidden">
            Original entry
          </summary>
          <p className="mt-3 whitespace-pre-line text-sm leading-6 text-muted">{spokenEntry}</p>
        </details>
      ) : null}
    </div>
  )
}
