export default function DashboardLoading() {
  return (
    <div aria-busy="true" aria-label="Loading nutrition log" className="space-y-8">
      <div className="shimmer h-11 w-72 rounded-2xl bg-surface" />
      <div className="shimmer h-64 rounded-[2rem] bg-surface" />
      <div className="grid gap-8 lg:grid-cols-[minmax(0,1.35fr)_minmax(16rem,0.65fr)]">
        <div className="shimmer h-80 rounded-[1.75rem] bg-surface" />
        <div className="shimmer h-56 rounded-[1.75rem] bg-surface" />
      </div>
    </div>
  )
}
