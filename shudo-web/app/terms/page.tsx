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
      summary="Plain-language terms for the Shudo private beta."
      title="Terms of use"
    >
      <PublicSection title="Use the beta responsibly">
        <p>
          Use only your own account, protect its sign-in links, and do not interfere with Shudo,
          bypass its access controls, send abusive traffic, or upload content you cannot lawfully use.
        </p>
      </PublicSection>

      <PublicSection title="Your meal content">
        <p>
          Your descriptions, recordings, and photos remain yours. Shudo processes them to operate,
          secure, and support the service. You can delete meals or your account in the app.
        </p>
      </PublicSection>

      <PublicSection title="Estimates, not medical advice">
        <p>
          AI transcripts, portions, ingredients, calories, and macros can be wrong. Shudo is not
          medical, allergy, or emergency advice. Check important decisions against labels and a
          qualified professional.
        </p>
      </PublicSection>

      <PublicSection title="Beta availability">
        <p>
          This is a small private beta provided as available. Features may change or stop, and access
          may be limited for misuse or security risk. Email{' '}
          <a href={SHUDO_SUPPORT_MAILTO}>{SHUDO_SUPPORT_EMAIL}</a> for help or if in-app deletion is
          unavailable. Material term changes will be dated here.
        </p>
      </PublicSection>
    </PublicPageShell>
  )
}
