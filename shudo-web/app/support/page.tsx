import type { Metadata } from 'next'
import { PublicPageShell, PublicSection } from '@/components/public/public-page-shell'
import { SHUDO_SUPPORT_EMAIL, SHUDO_SUPPORT_MAILTO } from '@/lib/public-information'

export const metadata: Metadata = {
  title: 'Support',
  description: 'Help with Shudo sign-in, meal processing, and account access.',
}

export default function SupportPage() {
  return (
    <PublicPageShell
      currentPath="/support"
      eyebrow="Support"
      summary="Help with sign-in, meal processing, and account access."
      title="Shudo support"
    >
      <div className="rounded-2xl bg-surface-strong px-5 py-5">
        <p className="text-xs font-medium uppercase tracking-[0.16em] text-subtle">Contact</p>
        <a
          className="mt-2 inline-flex rounded-lg text-lg font-semibold text-ink underline decoration-subtle underline-offset-4 transition hover:text-accent focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent/70"
          href={SHUDO_SUPPORT_MAILTO}
        >
          {SHUDO_SUPPORT_EMAIL}
        </a>
        <p className="mt-2 text-sm leading-6 text-muted">
          Include the account email and a short description. Do not send a password, access token,
          or recovery link.
        </p>
      </div>

      <PublicSection title="Sign-in help">
        <ul>
          <li>Request a new email link if the previous link is expired or already used.</li>
          <li>Use the newest email when several sign-in or reset messages were requested.</li>
          <li>For Apple or Google sign-in, use the provider connected to the Shudo account.</li>
        </ul>
      </PublicSection>

      <PublicSection title="Meal processing">
        <p>
          A failed meal can be retried from the app. If the same entry keeps failing, send the meal
          date, approximate time, and the message shown in Shudo. Avoid attaching the meal photo or
          recording unless support requests it.
        </p>
      </PublicSection>

      <PublicSection title="Account deletion">
        <p>
          Delete individual meals or the full account directly in Shudo Settings. Email support if
          the in-app deletion path is unavailable. Account ownership may need to be verified for a
          support request.
        </p>
      </PublicSection>

      <PublicSection title="What to include">
        <ul>
          <li>The email address used for Shudo.</li>
          <li>The device model and iOS version when the issue is device-specific.</li>
          <li>A concise description and, if useful, a screenshot with private details removed.</li>
        </ul>
      </PublicSection>
    </PublicPageShell>
  )
}
