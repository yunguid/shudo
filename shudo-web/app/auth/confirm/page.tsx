import type { Metadata } from 'next'
import { AuthShell } from '@/components/auth/auth-shell'
import { EmailConfirmation } from '@/components/auth/email-confirmation'

export const metadata: Metadata = {
  title: 'Confirm email',
}

export default function ConfirmEmailPage() {
  return (
    <AuthShell>
      <EmailConfirmation />
    </AuthShell>
  )
}
