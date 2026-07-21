import { redirect } from 'next/navigation'
import { TopBar } from '@/components/layout/top-bar'
import { getCurrentUser } from '@/lib/auth'

export default async function DashboardLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser()
  if (!user) redirect('/auth/login')

  return (
    <div className="min-h-screen">
      <TopBar />
      <main
        className="mx-auto w-full max-w-5xl scroll-mt-20 px-5 pb-16 pt-8 sm:px-8 sm:pt-10"
        id="main-content"
        tabIndex={-1}
      >
        {children}
      </main>
    </div>
  )
}
