import type { Metadata } from 'next'
import { PublicPageShell, PublicSection } from '@/components/public/public-page-shell'
import { SHUDO_SUPPORT_EMAIL, SHUDO_SUPPORT_MAILTO } from '@/lib/public-information'

export const metadata: Metadata = {
  title: 'Terms of use',
  description: 'The terms for using the Shudo meal logging app and web companion.',
}

export default function TermsPage() {
  return (
    <PublicPageShell
      currentPath="/terms"
      eyebrow="Terms"
      summary="These terms cover use of Shudo, a focused meal log that turns voice, photos, and text into nutrition estimates."
      title="Terms of use"
    >
      <PublicSection title="Using Shudo">
        <p>
          Use only an account you are authorized to access. Keep sign-in links, passwords, devices,
          and recovery links secure. Contact support if account access may be compromised.
        </p>
        <p>
          Do not interfere with the service, bypass access controls, automate abusive traffic, or
          submit unlawful or infringing content.
        </p>
      </PublicSection>

      <PublicSection title="Meal content">
        <p>
          Meal descriptions, recordings, and photos remain the user&apos;s content. Shudo may process
          that content only as needed to operate, secure, and support the service. Upload content
          only when the necessary rights and permissions are held.
        </p>
      </PublicSection>

      <PublicSection title="Nutrition and AI limits">
        <p>
          Transcripts and nutrition estimates are generated automatically and may be incomplete or
          wrong. Portion sizes, calories, macros, ingredients, and confidence values are estimates,
          not measurements.
        </p>
        <p>
          Shudo is not medical, dietary, allergy, or emergency advice. Do not rely on it to manage a
          health condition, medication, food allergy, or urgent decision. Verify important
          information with qualified professionals and product labels.
        </p>
      </PublicSection>

      <PublicSection title="Availability and providers">
        <p>
          Shudo depends on Apple or Google sign-in when selected, Supabase, OpenAI, Vercel, network
          access, and the device operating system. Features may change, pause, or stop, and
          uninterrupted availability is not guaranteed.
        </p>
        <p>Third-party services are also governed by their own terms and privacy notices.</p>
      </PublicSection>

      <PublicSection title="Ending use">
        <p>
          Individual meals and the full account can be deleted in the app. Email{' '}
          <a href={SHUDO_SUPPORT_MAILTO}>{SHUDO_SUPPORT_EMAIL}</a> if in-app deletion is unavailable.
          Access may be limited or ended to address misuse, security risk, legal requirements, or
          service closure.
        </p>
      </PublicSection>

      <PublicSection title="Service standard">
        <p>
          Shudo is provided on an as-available basis. To the extent permitted by law, no warranty is
          made about uninterrupted operation or the accuracy of generated nutrition information.
          These terms do not limit rights or responsibilities that cannot lawfully be limited.
        </p>
      </PublicSection>

      <PublicSection title="Questions and updates">
        <p>
          Questions can be sent to <a href={SHUDO_SUPPORT_MAILTO}>{SHUDO_SUPPORT_EMAIL}</a>. Material
          changes will be posted here with a revised update date.
        </p>
      </PublicSection>
    </PublicPageShell>
  )
}
